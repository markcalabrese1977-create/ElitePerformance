import XCTest
import SwiftData
@testable import ElitePerformance

final class InsertDeloadWeekTests: XCTestCase {

    private typealias Service = SessionItemEditService

    private var container: ModelContainer!
    private let scheduledKey = "meso.scheduledStartDateEpoch"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: scheduledKey)
    }
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: scheduledKey)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func cal() -> Calendar { Calendar.current }
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal().date(from: DateComponents(year: y, month: m, day: d))!
    }
    private func day(_ d: Date) -> Date { cal().startOfDay(for: d) }
    private func plus(_ d: Date, _ n: Int) -> Date { cal().date(byAdding: .day, value: n, to: d)! }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        return ModelContext(c)
    }

    /// The real 10-week DUP block converted to 12 weeks (Fri Sep 25 2026 start, six days a week).
    private func makeDUPBlock() throws -> (ModelContext, MesoBlock) {
        let ctx = try makeContext()
        ctx.insert(User(units: .lb, progressionEnabled: true))
        try DUPProgramSeeder.seed(
            startDate: date(2026, 9, 25), trainingWeekdays: [1, 2, 3, 4, 6, 7], context: ctx,
            template: DUP10WeekTemplate.template, calendar: cal(),
            mesoName: "10-Week DUP Meso", mesoStatus: .active
        )
        let block = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MesoBlock>()).first)
        try DUPMesoLengthConversion.apply(block: block, context: ctx, calendar: cal())
        XCTAssertEqual(block.totalWeeks, 12)
        try ctx.save()
        return (ctx, block)
    }

    private func sorted(_ block: MesoBlock) -> [Session] { block.sessions.sorted { ($0.date, $0.programIndex ?? 0) < ($1.date, $1.programIndex ?? 0) } }
    private func week(_ block: MesoBlock, _ w: Int) -> [Session] { sorted(block).filter { $0.weekIndex == w } }

    private func finish(_ s: Session, load: Double, reps: Int = 10) {
        for i in s.items {
            let n = max(1, i.targetSets)
            i.actualLoads = Array(repeating: load, count: n)
            i.actualReps = Array(repeating: reps, count: n)
            i.actualRIRs = Array(repeating: 2, count: n)
            i.isCompleted = true
        }
        s.status = .completed
    }

    /// Completes weeks 1-4 of the DUP block and returns `now` = the first day of week 5.
    private func completeFirstFourWeeks(_ block: MesoBlock, load: Double = 100) -> Date {
        for w in 1...4 { for s in week(block, w) { finish(s, load: load) } }
        return day(week(block, 5).map(\.date).min()!)
    }

    private func item(_ i: Int, _ id: String, wave: String? = nil, sets: Int = 4, reps: ClosedRange<Int> = 8...10) -> SessionItem {
        SessionItem(order: i, exerciseId: id, targetReps: reps.lowerBound, targetSets: sets, targetRIR: 2, suggestedLoad: 0,
                    waveRaw: wave, setMin: sets - 1, setMax: sets + 1, repMin: reps.lowerBound, repMax: reps.upperBound,
                    targetRIRMin: 1, targetRIRMax: 2,
                    plannedRepsBySet: Array(repeating: reps.lowerBound, count: sets),
                    plannedLoadsBySet: Array(repeating: 0, count: sets),
                    plannedRIRsBySet: Array(repeating: 2, count: sets))
    }

    /// A non-wave block: `weeks` weeks of one session each, `start` + 7 * (week - 1).
    private func makeSimpleBlock(_ ctx: ModelContext, weeks: Int, start: Date, ids: [String] = ["leg_extension"],
                                 status: MesoStatus = .active) throws -> MesoBlock {
        let block = MesoBlock(name: "Simple", startDate: start, status: status, totalWeeks: weeks)
        ctx.insert(block)
        for w in 1...weeks {
            let s = Session(date: plus(start, 7 * (w - 1)), status: .planned, weekIndex: w, dayLabel: "Legs",
                            items: ids.enumerated().map { item($0.offset + 1, $0.element) }, programIndex: w)
            s.meso = block
            ctx.insert(s)
        }
        try ctx.save()
        return block
    }

    private func snapshot(_ ctx: ModelContext) throws -> [String] {
        var out: [String] = []
        for s in try ctx.fetch(FetchDescriptor<Session>()).sorted(by: { ($0.date, $0.dayLabel ?? "", $0.id?.uuidString ?? "") < ($1.date, $1.dayLabel ?? "", $1.id?.uuidString ?? "") }) {
            out.append("S|\(s.id?.uuidString ?? "")|\(s.date.timeIntervalSince1970)|\(s.status.rawValue)|\(s.weekIndex)|\(s.programIndex.map(String.init) ?? "-")|\(s.insertedDeload.map(String.init) ?? "-")|\(s.items.count)")
            for i in s.items.sorted(by: { ($0.order, $0.exerciseId) < ($1.order, $1.exerciseId) }) {
                out.append("I|\(i.id?.uuidString ?? "")|\(i.exerciseId)|\(i.waveRaw ?? "-")|\(i.targetSets)|\(i.suggestedLoad)|\(i.plannedLoadsBySet)|\(i.actualLoads)")
            }
        }
        for m in try ctx.fetch(FetchDescriptor<MesoBlock>()) { out.append("M|\(m.totalWeeks.map(String.init) ?? "-")|\(m.sessions.count)") }
        return out
    }

    // MARK: - Plan

    func test_plan_12weekBlock_insertAtWeek5_isReadOnlyAndCountsMatch() throws {
        let (ctx, block) = try makeDUPBlock()
        let now = completeFirstFourWeeks(block)
        try ctx.save()
        let w5 = week(block, 5)
        XCTAssertEqual(w5.count, 6)

        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now)
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.weekIndex, 5)
        XCTAssertEqual(plan.deloadSessions.count, 6)
        XCTAssertEqual(plan.deloadSessions.map(\.date), w5.map(\.date))
        XCTAssertEqual(plan.shifted.count, sorted(block).filter { $0.weekIndex >= 5 }.count)
        XCTAssertEqual(plan.blockEndAfter, plus(try XCTUnwrap(plan.blockEndBefore), 7))
        XCTAssertFalse(ctx.hasChanges, "planning never writes")
        XCTAssertEqual(block.totalWeeks, 12)
    }

    // MARK: - Apply: 12-week DUP fixture

    func test_apply_12weekBlock_insertAtWeek5() throws {
        let (ctx, block) = try makeDUPBlock()
        let now = completeFirstFourWeeks(block)
        try ctx.save()
        let w5Before = week(block, 5)
        let w5Dates = w5Before.map(\.date)
        let w5Labels = w5Before.map { $0.dayLabel }
        let laterBefore = sorted(block).filter { $0.weekIndex >= 5 }
        let totalBefore = block.sessions.count
        let sourceTargets = week(block, 4).flatMap { s in s.items.map { (s, $0) } }
            .map { src in (src, PlanMemoryEngine.nextTargetItem(for: src.1, after: src.0, in: sorted(block))) }

        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now)
        let result = try Service.insertDeloadWeek(plan, in: ctx)

        XCTAssertEqual(result.deloadSessionsCreated, plan.deloadSessions.count)
        XCTAssertEqual(result.sessionsShifted, plan.shifted.count)
        XCTAssertEqual(block.sessions.count, totalBefore + 6)
        XCTAssertEqual(block.totalWeeks, 13)

        let inserted = sorted(block).filter { $0.insertedDeload == true }
        XCTAssertEqual(inserted.count, 6)
        XCTAssertEqual(inserted.map(\.date), w5Dates, "deload sits on the old week-5 dates")
        XCTAssertEqual(inserted.map { $0.dayLabel }, w5Labels)
        XCTAssertTrue(inserted.allSatisfy { $0.weekIndex == 5 && $0.status == .planned })
        XCTAssertTrue(inserted.allSatisfy { $0.items.allSatisfy { $0.waveRaw == "deload" } })
        XCTAssertTrue(sorted(block).filter { $0.insertedDeload != true }.allSatisfy { $0.insertedDeload == nil })

        // Weeks 5-12 are now 6-13, a week later.
        XCTAssertEqual(Set(block.sessions.map(\.weekIndex)), Set(1...13))
        XCTAssertEqual(week(block, 6).map(\.date), w5Dates.map { plus($0, 7) })
        XCTAssertEqual(sorted(block).filter { $0.insertedDeload != true && $0.weekIndex >= 6 }.count, laterBefore.count)

        // programIndex runs 1...N in date order.
        let indices = sorted(block).compactMap(\.programIndex)
        XCTAssertEqual(indices.count, block.sessions.count)
        XCTAssertEqual(indices, Array(1...indices.count))

        // Chains: every week-4 result still flows to the same target, now a week later, never a deload item.
        for (src, before) in sourceTargets {
            let after = PlanMemoryEngine.nextTargetItem(for: src.1, after: src.0, in: sorted(block))
            XCTAssertTrue(after === before, "\(src.1.exerciseId) chain moved")
            XCTAssertNotEqual(after?.waveRaw, "deload")
        }

        // Day labels still count 1...6 within every week.
        for w in 1...13 { XCTAssertEqual(week(block, w).map(\.dayNumberInWeek), Array(1...6), "week \(w)") }
    }

    func test_apply_deloadPrescription_halfSets_sameReps_RIR34_widenedBands_loadsFromHistory_arraysSized() throws {
        let (ctx, block) = try makeDUPBlock()
        let now = completeFirstFourWeeks(block)
        let sources = week(block, 5)
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now)
        try Service.insertDeloadWeek(plan, in: ctx)

        let inserted = sorted(block).filter { $0.insertedDeload == true }
        for (dep, src) in zip(inserted, sources) {
            XCTAssertEqual(dep.items.count, src.items.count)
            for (d, s) in zip(dep.items.sorted { $0.order < $1.order }, src.items.sorted { $0.order < $1.order }) {
                let n = max(1, Int((Double(s.targetSets) / 2).rounded(.up)))
                XCTAssertEqual(d.exerciseId, s.exerciseId)
                XCTAssertEqual(d.order, s.order)
                XCTAssertEqual(d.targetSets, n)
                XCTAssertEqual(d.repMin, s.repMin ?? s.targetReps)
                XCTAssertEqual(d.repMax, s.repMax ?? s.targetReps)
                XCTAssertEqual(d.targetReps, d.repMin)
                XCTAssertEqual([d.targetRIRMin, d.targetRIRMax, d.targetRIR], [3, 4, 4])
                if let lo = d.setMin { XCTAssertLessThanOrEqual(lo, n) }
                if let hi = d.setMax { XCTAssertGreaterThanOrEqual(hi, n) }
                for count in [d.plannedRepsBySet.count, d.plannedLoadsBySet.count, d.plannedRIRsBySet.count, d.actualLoads.count,
                              d.actualReps.count, d.actualRIRs.count, d.usedRestPauseFlags.count, d.restPausePatternsBySet.count,
                              d.dropSetPatternsBySet.count, d.setFeedbackBySet.count, d.pumpRatingsBySet.count] {
                    XCTAssertEqual(count, n)
                }
                if ExerciseCatalog.isBodyweight(exerciseId: d.exerciseId) {
                    XCTAssertEqual(d.suggestedLoad, 0)
                } else {
                    XCTAssertGreaterThan(d.suggestedLoad, 0, "history at 100 -> a positive seed")
                    let expected = HistorySeedLoad.load(
                        for: d.exerciseId, goalReps: d.repMax ?? d.targetReps, targetRIR: 4,
                        in: sorted(block).filter { $0.status == .completed }, loadIncrement: 2.5, referenceDate: now)
                    XCTAssertEqual(d.suggestedLoad, expected, "the seed is HistorySeedLoad at (top of the rep range, RIR 4)")
                    XCTAssertEqual(d.suggestedLoad.truncatingRemainder(dividingBy: 2.5), 0, accuracy: 1e-9, "rounded down to the increment")
                }
                XCTAssertFalse(d.planEdited)
                XCTAssertFalse(SessionEditSafety.hasLoggedData(d))
            }
        }
    }

    // MARK: - Apply: non-wave block, loads

    func test_apply_nonWaveBlock_workingFeedsWorking_notTheDeload() throws {
        let ctx = try makeContext()
        let now = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 4, start: now)
        let s1 = week(block, 1)[0]
        finish(s1, load: 100)
        try ctx.save()
        let target = PlanMemoryEngine.nextTargetItem(for: s1.items[0], after: s1, in: sorted(block))
        XCTAssertEqual(target?.waveRaw, nil)
        let owner = block.sessions.first(where: { s in s.items.contains(where: { $0 === target }) })
        XCTAssertEqual(owner?.weekIndex, 2)

        // Today = week 2's day, so week 2 is the first not-started week.
        let insertNow = plus(now, 7)
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: insertNow)
        XCTAssertEqual(plan.weekIndex, 2)
        try Service.insertDeloadWeek(plan, in: ctx)

        XCTAssertEqual(block.totalWeeks, 5)
        XCTAssertEqual(week(block, 2).first?.insertedDeload, true)
        XCTAssertEqual(week(block, 2).first?.items.first?.waveRaw, "deload")
        let after = try XCTUnwrap(PlanMemoryEngine.nextTargetItem(for: s1.items[0], after: s1, in: sorted(block)))
        XCTAssertTrue(after === target, "same working session as before")
        XCTAssertEqual(block.sessions.first(where: { s in s.items.contains(where: { $0 === after }) })?.weekIndex, 3)
        XCTAssertNotEqual(after.waveRaw, "deload")
    }

    func test_apply_earlierOriginalDeload_doesNotBlockTheInsert() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 6, start: start)
        // Weeks 2 and 5 were generated as deloads; the lifter inserts another at week 3.
        for w in [2, 5] { for i in week(block, w).flatMap(\.items) { i.waveRaw = "deload" } }
        try ctx.save()
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: plus(start, 14))
        XCTAssertEqual(plan.weekIndex, 3)
        XCTAssertNoThrow(try Service.insertDeloadWeek(plan, in: ctx), "the week-2 deload now chains to the inserted deload; that is not a problem")
        XCTAssertEqual(block.totalWeeks, 7)
        XCTAssertEqual(week(block, 3).first?.insertedDeload, true)
    }

    func test_apply_fixedLoadExercise_holdsLastCompletedLoad() throws {
        let ctx = try makeContext()
        let profile = UserProfile()
        profile.setProgressionExempt(true, exerciseId: "leg_extension")
        ctx.insert(profile)
        let now = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 3, start: now)
        finish(week(block, 1)[0], load: 135)
        try ctx.save()
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: plus(now, 7))
        try Service.insertDeloadWeek(plan, in: ctx)
        let dep = try XCTUnwrap(week(block, 2).first)
        XCTAssertEqual(dep.items[0].suggestedLoad, 135)
        XCTAssertEqual(dep.items[0].plannedLoadsBySet, [135, 135])
    }

    func test_apply_bodyweightExercise_isZero_andNoHistoryIsZero() throws {
        let ctx = try makeContext()
        let bw = try XCTUnwrap(ExerciseCatalog.all.first(where: { $0.isBodyweight })).id
        let now = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 3, start: now, ids: [bw, "leg_extension"])
        finish(week(block, 1)[0], load: 25)   // bodyweight and leg extension both have history here...
        try ctx.save()
        let loaded = Service.planInsertDeloadWeek(meso: block, context: ctx, now: plus(now, 7))
        try Service.insertDeloadWeek(loaded, in: ctx)
        let dep = try XCTUnwrap(week(block, 2).first)
        let byId = Dictionary(uniqueKeysWithValues: dep.items.map { ($0.exerciseId, $0) })
        XCTAssertEqual(byId[bw]?.suggestedLoad, 0)
        XCTAssertGreaterThan(byId["leg_extension"]?.suggestedLoad ?? 0, 0)

        // A different lift with no history at all starts at 0.
        let ctx2 = try makeContext()
        let block2 = try makeSimpleBlock(ctx2, weeks: 2, start: now)
        let plan2 = Service.planInsertDeloadWeek(meso: block2, context: ctx2, now: now)
        try Service.insertDeloadWeek(plan2, in: ctx2)
        XCTAssertEqual(week(block2, 1).first?.items.first?.suggestedLoad, 0)
        XCTAssertEqual(week(block2, 1).first?.items.first?.plannedLoadsBySet, [0, 0])
    }

    // MARK: - Refusals

    func test_refuses_whenASessionIsInProgress() throws {
        let ctx = try makeContext()
        let now = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 3, start: now)
        week(block, 1)[0].status = .inProgress
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now)
        XCTAssertEqual(plan.refusal, .sessionInProgress)
        XCTAssertFalse(plan.isApplicable)
        XCTAssertThrowsError(try Service.insertDeloadWeek(plan, in: ctx)) {
            XCTAssertEqual($0 as? Service.InsertDeloadError, .refused(.sessionInProgress))
        }
    }

    func test_refuses_whenNoWeekIsEligible() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 3, start: start)
        // Everything is in the past.
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: plus(start, 60))
        XCTAssertEqual(plan.refusal, .noEligibleWeek)
        // A week with a logged session is not eligible either; the next one is.
        let ctx2 = try makeContext()
        let b2 = try makeSimpleBlock(ctx2, weeks: 3, start: start)
        week(b2, 1)[0].items[0].actualLoads = [50]
        XCTAssertEqual(Service.planInsertDeloadWeek(meso: b2, context: ctx2, now: start).weekIndex, 2)
    }

    func test_refuses_inactiveBlock_andLaterCompletedSession() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let done = try makeSimpleBlock(ctx, weeks: 3, start: start, status: .archived)
        XCTAssertEqual(Service.planInsertDeloadWeek(meso: done, context: ctx, now: start).refusal, .inactiveMeso)

        let ctx2 = try makeContext()
        let b = try makeSimpleBlock(ctx2, weeks: 4, start: start)
        finish(week(b, 3)[0], load: 100)   // a later week was trained out of order
        let plan = Service.planInsertDeloadWeek(meso: b, context: ctx2, now: start)
        XCTAssertEqual(plan.refusal, .laterSessionCompleted)
    }

    func test_refuses_andListsCollisionsWithAnotherBlocksSession() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 3, start: start)
        let other = MesoBlock(name: "Other", startDate: start, status: .archived, totalWeeks: 1)
        ctx.insert(other)
        // Week 2's session (Nov 9) moves to Nov 16; park another block's session there.
        let blocker = Session(date: plus(start, 14), status: .completed, weekIndex: 1, dayLabel: "Old")
        blocker.meso = other
        ctx.insert(blocker)
        try ctx.save()
        let before = try snapshot(ctx)

        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: plus(start, 7))
        XCTAssertEqual(plan.refusal, .dateCollision)
        XCTAssertEqual(plan.collisions.count, 1)
        XCTAssertTrue(plan.collisions[0].occupant === blocker)
        XCTAssertEqual(plan.collisions[0].date, plus(start, 14))
        XCTAssertThrowsError(try Service.insertDeloadWeek(plan, in: ctx))
        XCTAssertEqual(try snapshot(ctx), before)
    }

    func test_stalePlan_isRefusedWithoutWriting() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 4, start: start)
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: start)
        XCTAssertEqual(plan.weekIndex, 1)
        week(block, 1)[0].items[0].actualLoads = [50]   // week 1 got logged after the preview
        try ctx.save()
        let before = try snapshot(ctx)
        XCTAssertThrowsError(try Service.insertDeloadWeek(plan, in: ctx)) {
            XCTAssertEqual($0 as? Service.InsertDeloadError, .planStale)
        }
        XCTAssertEqual(try snapshot(ctx), before)
    }

    // MARK: - Rollback

    func test_forcedVerificationFailure_leavesEveryFieldUnchanged() throws {
        let (ctx, block) = try makeDUPBlock()
        let now = completeFirstFourWeeks(block)
        try ctx.save()
        let before = try snapshot(ctx)
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now)
        XCTAssertThrowsError(try Service.insertDeloadWeek(plan, in: ctx, hooks: .init(forceVerificationFailure: true))) {
            guard case .verificationFailed(let problems)? = $0 as? Service.InsertDeloadError else { return XCTFail("\($0)") }
            XCTAssertEqual(problems.count, 1, "only the forced failure: \(problems)")
        }
        XCTAssertEqual(try snapshot(ctx), before)
        XCTAssertEqual(block.totalWeeks, 12)
        XCTAssertFalse(ctx.hasChanges)
    }

    func test_forcedSaveFailure_leavesEveryFieldUnchanged_andNextMesoDateAlone() throws {
        let (ctx, block) = try makeDUPBlock()
        let now = completeFirstFourWeeks(block)
        try ctx.save()
        let next = date(2027, 1, 4)
        MesoLifecycle.scheduleNextMeso(on: next)
        let before = try snapshot(ctx)
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now)
        XCTAssertThrowsError(try Service.insertDeloadWeek(plan, in: ctx, hooks: .init(forceSaveFailure: true))) {
            guard case .saveFailed? = $0 as? Service.InsertDeloadError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try snapshot(ctx), before)
        XCTAssertEqual(MesoLifecycle.scheduledStartDate, day(next))
        // And the same plan still applies afterwards.
        XCTAssertNoThrow(try Service.insertDeloadWeek(Service.planInsertDeloadWeek(meso: block, context: ctx, now: now), in: ctx))
    }

    // MARK: - Next block start

    func test_scheduledNextMeso_movesAWeekLater_andIsLeftAloneWhenUnset() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 3, start: start)
        MesoLifecycle.scheduleNextMeso(on: date(2027, 1, 4))
        try Service.insertDeloadWeek(Service.planInsertDeloadWeek(meso: block, context: ctx, now: start), in: ctx)
        XCTAssertEqual(MesoLifecycle.scheduledStartDate, day(date(2027, 1, 11)))

        UserDefaults.standard.removeObject(forKey: scheduledKey)
        let ctx2 = try makeContext()
        let b2 = try makeSimpleBlock(ctx2, weeks: 3, start: start)
        try Service.insertDeloadWeek(Service.planInsertDeloadWeek(meso: b2, context: ctx2, now: start), in: ctx2)
        XCTAssertNil(MesoLifecycle.scheduledStartDate)
    }

    // MARK: - Choosing the week

    func test_explicitWeek_planFollowsTheChoice_andNilIsTheFirstEligible() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 5, start: start)
        let now = plus(start, 7)                       // week 1 is past
        XCTAssertEqual(Service.eligibleDeloadWeeks(meso: block, now: now), [2, 3, 4, 5])
        XCTAssertEqual(Service.planInsertDeloadWeek(meso: block, context: ctx, now: now).weekIndex, 2)

        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now, week: 4)
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.weekIndex, 4)
        XCTAssertEqual(plan.deloadSessions.map(\.date), week(block, 4).map(\.date))
        XCTAssertEqual(plan.shifted.count, 2, "weeks 4 and 5 move")

        try Service.insertDeloadWeek(plan, in: ctx)
        XCTAssertEqual(block.totalWeeks, 6)
        XCTAssertEqual(week(block, 4).first?.insertedDeload, true)
        XCTAssertNil(week(block, 3).first?.insertedDeload, "earlier weeks untouched")
        XCTAssertEqual(week(block, 3).first?.date, plus(start, 14))
        XCTAssertEqual(week(block, 5).first?.date, plus(start, 28))
        XCTAssertEqual(week(block, 6).first?.date, plus(start, 35))
    }

    func test_explicitIneligibleWeek_isRefusedWithAReason() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 4, start: start)
        week(block, 3).first?.items[0].waveRaw = "deload"
        week(block, 4).first?.items[0].actualLoads = [50]
        let now = plus(start, 7)
        for w in [1, 3, 4, 9] {
            let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now, week: w)
            XCTAssertEqual(plan.refusal, .weekNotEligible, "week \(w)")
            XCTAssertFalse(plan.isApplicable)
        }
        XCTAssertEqual(Service.eligibleDeloadWeeks(meso: block, now: now), [2])
    }

    func test_removeCanTargetASpecificInsertedWeek() throws {
        let ctx = try makeContext()
        let start = date(2026, 11, 2)
        let block = try makeSimpleBlock(ctx, weeks: 5, start: start)
        try Service.insertDeloadWeek(Service.planInsertDeloadWeek(meso: block, context: ctx, now: start, week: 2), in: ctx)
        try Service.insertDeloadWeek(Service.planInsertDeloadWeek(meso: block, context: ctx, now: start, week: 5), in: ctx)
        XCTAssertEqual(block.sessions.filter { $0.insertedDeload == true }.map(\.weekIndex).sorted(), [2, 5])
        let plan = Service.planRemoveInsertedDeloadWeek(meso: block, context: ctx, now: start, week: 5)
        XCTAssertEqual(plan.weekIndex, 5)
        try Service.removeInsertedDeloadWeek(plan, in: ctx)
        XCTAssertEqual(block.sessions.filter { $0.insertedDeload == true }.map(\.weekIndex), [2])
        XCTAssertEqual(Service.planRemoveInsertedDeloadWeek(meso: block, context: ctx, now: start, week: 3).refusal, .noInsertedDeload)
    }

    // MARK: - Top set

    /// A deload is straight sets: the top set is dropped, and the sets and load come from the back-offs only.
    func test_apply_deloadDropsTheTopSet_workingWeeksKeepIt() throws {
        let (ctx, block) = try makeDUPBlock()
        let now = completeFirstFourWeeks(block)
        for w in [5, 6] {
            for s in week(block, w) {
                for i in s.items {
                    let n = i.targetSets
                    i.setRolesBySet = SessionItem.roles(backOffs: n, tops: 1)
                    i.topRepMin = 4; i.topRepMax = 6; i.topRIR = 2
                    i.plannedLoadsBySet = Array(i.plannedLoadsBySet.prefix(n)) + [315]
                    i.plannedRepsBySet = Array(i.plannedRepsBySet.prefix(n)) + [4]
                    i.plannedRIRsBySet = Array(i.plannedRIRsBySet.prefix(n)) + [2]
                }
            }
        }
        try ctx.save()
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now)
        try Service.insertDeloadWeek(plan, in: ctx)
        let deload = sorted(block).filter { $0.insertedDeload == true }
        XCTAssertFalse(deload.isEmpty)
        for s in deload {
            for i in s.items {
                XCTAssertNil(i.setRolesBySet, "a deload item carries no top set")
                XCTAssertEqual(i.plannedLoadsBySet.count, i.targetSets)
                XCTAssertFalse(i.hasTopSet)
            }
        }
        // The shifted working week keeps its top set.
        let shifted = sorted(block).filter { $0.weekIndex == 6 && $0.insertedDeload != true }
        XCTAssertTrue(shifted.flatMap(\.items).allSatisfy { $0.hasTopSet })
    }

    func test_lastCompletedLoad_readsBackOffsNotTheTopSet() {
        let item = SessionItem(order: 1, exerciseId: "leg_extension", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 100)
        item.setRolesBySet = SessionItem.roles(backOffs: 3, tops: 1)
        item.actualLoads = [100, 100, 100, 140]; item.actualReps = [8, 8, 8, 5]
        let s = Session(date: Date(timeIntervalSince1970: 1_000), status: .completed, weekIndex: 1, items: [item])
        XCTAssertEqual(Service.lastCompletedLoad(for: "leg_extension", in: [s]), 100)
    }

    // MARK: - Max load

    /// Deload loads solve from history; a max load caps them like every other seed.
    func test_deloadLoads_areClampedToTheMax() throws {
        let (ctx, block) = try makeDUPBlock()
        let now = completeFirstFourWeeks(block, load: 100)
        let target = try XCTUnwrap(week(block, 5).flatMap(\.items).first { !ExerciseCatalog.isBodyweight(exerciseId: $0.exerciseId) }).exerciseId
        let canonical = ExerciseCatalog.canonicalExerciseId(for: target)
        func loads(_ plan: Service.InsertDeloadPlan) -> [Double] {
            plan.deloadSessions.flatMap(\.items).filter { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical }.map(\.load)
        }
        let free = loads(Service.planInsertDeloadWeek(meso: block, context: ctx, now: now))
        XCTAssertFalse(free.isEmpty)
        XCTAssertTrue(free.allSatisfy { $0 > 40 }, "\(free)")
        let profile = UserProfile(); profile.setMaxLoad(40, exerciseId: target); ctx.insert(profile)
        try ctx.save()
        let capped = loads(Service.planInsertDeloadWeek(meso: block, context: ctx, now: now))
        XCTAssertTrue(capped.allSatisfy { $0 == 40 }, "\(capped)")
    }
}
