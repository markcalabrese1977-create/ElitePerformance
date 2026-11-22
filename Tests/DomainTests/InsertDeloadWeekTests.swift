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
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
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
                    let done = sorted(block).filter { $0.status == .completed }
                    let rirAtRepMin = try XCTUnwrap(HistorySeedLoad.load(
                        for: d.exerciseId, goalReps: d.repMin ?? d.targetReps, targetRIR: 4,
                        in: done, loadIncrement: 2.5, referenceDate: now))
                    XCTAssertEqual(d.suggestedLoad, min(rirAtRepMin, 95), "min(RIR-4 sizing at repMin, 0.95 x the working load of 100)")
                    XCTAssertLessThanOrEqual(d.suggestedLoad, 95)
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

// MARK: - DeloadRule

/// The one deload rule: half the sets, RIR 4, planned reps = repMin, load = min(RIR-4 sizing at repMin,
/// 0.95 x the latest non-deload working load), rounded down to the step.
final class DeloadRuleTests: XCTestCase {

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 86_400) }

    private func session(_ n: Int, _ id: String = "bench_press", load: Double, reps: Int, rir: Int = 1, sets: Int = 3,
                         wave: String? = "a", inserted: Bool = false) -> Session {
        let i = SessionItem(order: 1, exerciseId: id, targetReps: reps, targetSets: sets, targetRIR: 2, suggestedLoad: load, waveRaw: wave)
        i.actualLoads = Array(repeating: load, count: sets)
        i.actualReps = Array(repeating: reps, count: sets)
        i.actualRIRs = Array(repeating: rir, count: sets)
        let s = Session(date: day(n), status: .completed, weekIndex: n, items: [i])
        s.insertedDeload = inserted ? true : nil
        return s
    }

    private func sizing(_ id: String = "bench_press", repMin: Int, _ sessions: [Session], step: Double = 2.5,
                        exempt: [String]? = nil) -> DeloadRule.Sizing {
        let profile = UserProfile()
        profile.minLoadIncrement = step
        if let exempt { profile.exemptExerciseIds = exempt }
        return DeloadRule.sizing(exerciseId: id, repMin: repMin, in: sessions, profile: profile, unit: .lb,
                                 customExercises: [], referenceDate: day(100))
    }

    func test_sets_halfRoundedUp_atLeastOne() {
        XCTAssertEqual([1, 2, 3, 4, 5, 6].map(DeloadRule.sets(forPlanned:)), [1, 1, 2, 2, 3, 3])
    }

    func test_load_isNeverAboveNinetyFivePercentOfWorkingLoad_acrossTheRepBands() {
        for band in [(6, 8), (8, 10), (10, 12), (12, 15)] {
            for working in [20.0, 45, 100, 135, 225, 315] {
                // Trained at the top of the band, hard (RIR 0): the e1RM points high.
                let z = sizing(repMin: band.0, [session(1, load: working, reps: band.1, rir: 0)])
                XCTAssertLessThanOrEqual(z.load, working * 0.95 + 1e-9, "\(band) @ \(working): \(z)")
                XCTAssertGreaterThan(z.load, working * 0.5, "\(band) @ \(working): a deload is light, not absent: \(z)")
                XCTAssertEqual(z.load.truncatingRemainder(dividingBy: 2.5), 0, accuracy: 1e-9, "rounded to the step")
                XCTAssertEqual(z.load, min(z.rirLoad ?? .infinity, z.capLoad ?? .infinity), "load is the min of the two sides")
                XCTAssertEqual(z.workingLoad, working)
            }
        }
    }

    func test_capSide_whenTheEstimatePointsAboveTheLastWorkingLoad() {
        // 100 x 15 at RIR 0 estimates about 150; RIR-4 sizing at 6 reps is ~112, above 0.95 x 100.
        let z = sizing(repMin: 6, [session(1, load: 100, reps: 15, rir: 0)])
        XCTAssertEqual(z.basis, .cap)
        XCTAssertEqual(z.load, 95)
        XCTAssertGreaterThan(z.rirLoad ?? 0, 95)
    }

    func test_rirSide_whenTheEstimateIsBelowTheCap() {
        // 100 x 3 at RIR 0 estimates about 110; RIR-4 sizing at 8 reps is ~78.
        let z = sizing(repMin: 8, [session(1, load: 100, reps: 3, rir: 0)])
        XCTAssertEqual(z.basis, .rir)
        XCTAssertLessThan(z.load, 95)
        XCTAssertEqual(z.load, z.rirLoad)
    }

    func test_cap_roundsDownToTheStep() {
        // 0.95 x 100 = 95 on a 5 lb step is exactly 95; 0.95 x 101 = 95.95 -> 95; 0.95 x 120 = 114 -> 110.
        XCTAssertEqual(sizing(repMin: 6, [session(1, load: 120, reps: 15, rir: 0)], step: 5).load, 110)
        XCTAssertEqual(sizing(repMin: 6, [session(1, load: 100, reps: 15, rir: 0)], step: 5).load, 95)
    }

    func test_workingLoad_isTheLatestNonDeloadSession_notTheHeaviest() {
        let older = session(1, load: 200, reps: 8)
        let newer = session(5, load: 150, reps: 8)
        let deload = session(6, load: 90, reps: 8, wave: "deload")
        let insertedDeload = session(7, load: 80, reps: 8, wave: "a", inserted: true)
        XCTAssertEqual(DeloadRule.latestWorkingLoad(for: "bench_press", in: [older, newer, deload, insertedDeload]), 150)
    }

    func test_bodyweight_carriesNoLoad() {
        let z = sizing("pull_up", repMin: 8, [session(1, "pull_up", load: 0, reps: 8)])
        XCTAssertEqual(z.basis, .bodyweight)
        XCTAssertEqual(z.load, 0)
    }

    func test_fixedLoadLift_holdsItsLastLoad() {
        let z = sizing("bench_press", repMin: 8, [session(1, load: 120, reps: 8)], exempt: ["bench_press"])
        XCTAssertEqual(z.basis, .exempt)
        XCTAssertEqual(z.load, 120)
    }

    func test_noHistory_isZeroAndSaysSo() {
        let z = sizing(repMin: 8, [])
        XCTAssertEqual(z.basis, .noHistory)
        XCTAssertEqual(z.load, 0)
        XCTAssertNil(z.workingLoad)
    }

    func test_deloadItemsAreNotHistory() {
        let z = sizing(repMin: 8, [session(1, load: 100, reps: 8, wave: "deload")])
        XCTAssertEqual(z.basis, .noHistory)
    }
}

// MARK: - WaveSlotRestore (re-adding an exercise to a wave session)

final class WaveSlotRestoreTests: XCTestCase {

    private func ctx() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, MesoBlock.self, UserProfile.self, User.self, CustomExercise.self])
        return ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
    }

    private func item(_ id: String, wave: String?, sets: Int = 3, reps: ClosedRange<Int> = 10...12, rir: Int = 3) -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: id, targetReps: reps.lowerBound, targetSets: sets, targetRIR: rir, suggestedLoad: 0,
                            waveRaw: wave, priorityRaw: "standard", setMin: sets, setMax: sets, repMin: reps.lowerBound, repMax: reps.upperBound,
                            targetRIRMin: rir, targetRIRMax: rir)
        i.plannedRepsBySet = Array(repeating: reps.lowerBound, count: 4)
        i.plannedLoadsBySet = Array(repeating: 0, count: 4)
        return i
    }

    /// The generic item the add flows build: waveless, 3 x 10, RIR 2, four array slots.
    private func fresh(_ id: String) -> SessionItem {
        let i = SessionItem(order: 9, exerciseId: id, targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 0)
        i.plannedRepsBySet = [10, 10, 10, 10]; i.plannedLoadsBySet = [0, 0, 0, 0]; i.plannedRIRsBySet = [2, 2, 2, 2]
        i.actualReps = [0, 0, 0, 0]; i.actualLoads = [0, 0, 0, 0]; i.actualRIRs = RIREntry.unsetArray(count: 4)
        return i
    }

    private func block(_ c: ModelContext, weeks: [(Int, String, [SessionItem])]) -> (MesoBlock, [Session]) {
        let meso = MesoBlock(name: "12-Week DUP Meso", startDate: Date(timeIntervalSince1970: 1_800_000_000), status: .active, totalWeeks: 12)
        c.insert(meso)
        var out: [Session] = []
        for (w, _, items) in weeks {
            let s = Session(date: Date(timeIntervalSince1970: 1_800_000_000 + Double(w) * 7 * 86_400), status: .planned,
                            weekIndex: w, dayLabel: "Push A", items: items)
            s.meso = meso; meso.sessions.append(s); c.insert(s); out.append(s)
        }
        return (meso, out)
    }

    func test_reAdd_takesTheSessionsLetterAndTheSameLetterTemplate_notTheOtherLetters() throws {
        let c = try ctx()
        // Week 1 (a): curl 3 x 12-15 RIR 3. Week 2 (b), where it is re-added. Week 5 (b): curl 4 x 8-10 RIR 2. Week 3 (c): curl 4 x 6-8.
        let (_, ss) = block(c, weeks: [
            (1, "a", [item("ez_bar_curl", wave: "a", sets: 3, reps: 12...15, rir: 3), item("bench_press", wave: "a")]),
            (2, "b", [item("bench_press", wave: "b")]),
            (3, "c", [item("ez_bar_curl", wave: "c", sets: 4, reps: 6...8, rir: 1)]),
            (5, "b", [item("ez_bar_curl", wave: "b", sets: 4, reps: 8...10, rir: 2)])])
        let new = fresh("ez_bar_curl")
        let restored = WaveSlotRestore.restore(new, in: ss[1], allSessions: ss)
        XCTAssertTrue(restored)
        XCTAssertEqual(new.waveRaw, "b")
        XCTAssertEqual([new.repMin, new.repMax, new.targetRIRMin, new.targetRIRMax], [8, 10, 2, 2])
        XCTAssertEqual([new.targetSets, new.effectivePrescribedSets, new.targetReps, new.targetRIR], [4, 4, 8, 2])
        XCTAssertEqual(new.plannedRepsBySet, [8, 8, 8, 8])
        XCTAssertEqual(new.plannedRIRsBySet, [2, 2, 2, 2])
        XCTAssertEqual(new.plannedLoadsBySet.count, 4)
        XCTAssertEqual(new.actualReps, [0, 0, 0, 0])
    }

    func test_reAdd_withNoTemplateInTheBlock_usesThePreviousExposureOnThatLetter() throws {
        let c = try ctx()
        let (_, ss) = block(c, weeks: [(2, "b", [item("bench_press", wave: "b")])])
        let old = Session(date: Date(timeIntervalSince1970: 1_700_000_000), status: .completed, weekIndex: 2, dayLabel: "Push A",
                          items: [item("ez_bar_curl", wave: "b", sets: 2, reps: 9...11, rir: 2)])
        c.insert(old)
        let new = fresh("ez_bar_curl")
        XCTAssertTrue(WaveSlotRestore.restore(new, in: ss[0], allSessions: ss + [old]))
        XCTAssertEqual(new.waveRaw, "b")
        XCTAssertEqual([new.repMin, new.repMax, new.targetSets], [9, 11, 2])
    }

    func test_reAdd_withNoSource_onlyTakesTheLetter() throws {
        let c = try ctx()
        let (_, ss) = block(c, weeks: [(2, "b", [item("bench_press", wave: "b")])])
        let new = fresh("ez_bar_curl")
        XCTAssertTrue(WaveSlotRestore.restore(new, in: ss[0], allSessions: ss))
        XCTAssertEqual(new.waveRaw, "b")
        XCTAssertEqual([new.targetReps, new.targetSets, new.targetRIR], [10, 3, 2], "defaults stay")
        XCTAssertNil(new.repMin)
    }

    func test_reAdd_toAWaveBlock_neverCopiesALoadOrALoggedValue() throws {
        let c = try ctx()
        let tpl = item("ez_bar_curl", wave: "b", sets: 3, reps: 10...12, rir: 2)
        tpl.suggestedLoad = 80; tpl.plannedLoadsBySet = [80, 80, 80, 80]; tpl.actualLoads = [80, 80, 80, 80]; tpl.actualReps = [10, 10, 10, 10]
        let (_, ss) = block(c, weeks: [(2, "b", [item("bench_press", wave: "b")]), (5, "b", [tpl])])
        let new = fresh("ez_bar_curl"); new.suggestedLoad = 42; new.plannedLoadsBySet = [42, 42, 42, 42]
        WaveSlotRestore.restore(new, in: ss[0], allSessions: ss)
        XCTAssertEqual(new.suggestedLoad, 42)
        XCTAssertEqual(new.plannedLoadsBySet, [42, 42, 42, 42])
        XCTAssertEqual(new.actualLoads, [0, 0, 0, 0])
    }

    func test_reAdd_toANonWaveBlock_changesNothing() throws {
        let c = try ctx()
        let (_, ss) = block(c, weeks: [(2, "none", [item("bench_press", wave: nil)])])
        let new = fresh("ez_bar_curl")
        XCTAssertFalse(WaveSlotRestore.restore(new, in: ss[0], allSessions: ss))
        XCTAssertNil(new.waveRaw)
        XCTAssertEqual(new.targetSets, 3)
    }

    // MARK: Today "Apply to future <weekday>" is only offered where it can act

    @MainActor
    func test_applyToFutureDialog_isNotOfferedOnAWaveBlock() throws {
        let c = try ctx()
        let (_, ss) = block(c, weeks: [(2, "b", [item("bench_press", wave: "b")])])
        XCTAssertFalse(SessionScreenViewModel(session: ss[0]).addedExerciseCanPropagate)
    }

    @MainActor
    func test_applyToFutureDialog_isOfferedOnABlockWithNoWaves() throws {
        let c = try ctx()
        let (_, ss) = block(c, weeks: [(2, "none", [item("bench_press", wave: nil)])])
        XCTAssertTrue(SessionScreenViewModel(session: ss[0]).addedExerciseCanPropagate)
    }
}


// MARK: - Scheduled deload weeks are filled by PlaceholderRefresh

@MainActor
final class ScheduledDeloadFillTests: XCTestCase {

    private var parked: [ModelContainer] = []
    private let cal = Calendar.current
    private let now = Date()

    private func makeContext() throws -> ModelContext {
        let c = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        parked.append(c)
        let ctx = ModelContext(c)
        ctx.insert(User(units: .lb, progressionEnabled: true))
        return ctx
    }

    /// Seeds `template` so that its LAST week starts three days from now, completes every earlier session at 100 lb x 10, and returns
    /// (the sessions of the deload week or last week, all sessions).
    private func seed(_ template: ProgramTemplate, _ ctx: ModelContext) throws -> (week: [Session], all: [Session], deloadWeek: Int?) {
        let weeks = template.totalWeeks
        let start = cal.date(byAdding: .day, value: 3 - (weeks - 1) * 7, to: cal.startOfDay(for: now))!
        let weekday = cal.component(.weekday, from: start)
        let days = (0..<template.trainingDaysPerWeek).map { ((weekday - 1 + $0) % 7) + 1 }
        try DUPProgramSeeder.seed(startDate: start, trainingWeekdays: days, context: ctx, template: template, mesoName: "M", mesoStatus: .active)
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)]))
        let deloadWeek = template.weekRules.first(where: { $0.isDeload })?.weekNumber
        let lastWeek = deloadWeek ?? weeks
        for s in all where s.weekIndex < lastWeek {
            s.status = .completed
            for i in s.items {
                i.actualLoads = Array(repeating: 100, count: i.targetSets)
                i.actualReps = Array(repeating: 10, count: i.targetSets)
                i.actualRIRs = Array(repeating: 2, count: i.targetSets)
            }
        }
        try ctx.save()
        return (all.filter { $0.weekIndex == lastWeek }, all, deloadWeek)
    }

    func test_everyBuiltInTemplateWithAScheduledDeload_hasItsDeloadItemsFilled() throws {
        let own = ProgramTemplate.waveless(name: "Own", totalWeeks: 6, deloadFinalWeek: true, days: [
            WavelessDay(title: "A", slots: [.defaults(exerciseId: ExerciseCatalog.benchPress.id, isCompound: true),
                                           .defaults(exerciseId: ExerciseCatalog.dumbbellLateralRaise.id, isCompound: false)]),
            WavelessDay(title: "B", slots: [.defaults(exerciseId: ExerciseCatalog.romanianDeadlift.id, isCompound: true)])])
        let templates: [(String, ProgramTemplate)] = [
            ("PPL3Week", PPL3WeekTemplate.template), ("UpperLower4Day", UpperLower4DayTemplate.template),
            ("Hybrid5Day", Hybrid5DayTemplate.template), ("DUP10Week", DUP10WeekTemplate.template),
            ("PPL6Day", PPL6DayTemplate.template), ("FullBody2Day", FullBody2DayTemplate.template), ("Waveless", own)]
        var covered = 0
        var noHistory: [String] = []
        for (name, t) in templates {
            let ctx = try makeContext()
            let s = try seed(t, ctx)
            guard s.deloadWeek != nil else { continue }
            covered += 1
            let items = s.week.flatMap(\.items).filter { $0.waveRaw?.lowercased() == "deload" && $0.targetSets > 0 }
            XCTAssertFalse(items.isEmpty, "\(name): the deload week has deload items")
            let before = items.filter { $0.suggestedLoad > 0 }.count
            PlaceholderRefresh.run(in: ctx, now: now)
            let profile = try ctx.fetch(FetchDescriptor<UserProfile>()).first
            for i in items where !ExerciseCatalog.isBodyweight(exerciseId: i.exerciseId, customExercises: []) {
                let z = DeloadRule.sizing(exerciseId: i.exerciseId, repMin: i.repMin ?? i.targetReps, in: s.all, profile: profile,
                                          unit: .lb, customExercises: [], referenceDate: now)
                if z.basis == .noHistory { print("SDL| \(name) \(i.exerciseId) sets \(i.targetSets) repMin \(String(describing: i.repMin)) \(i.targetReps)"); noHistory.append("\(name) \(i.exerciseId)"); XCTAssertEqual(i.suggestedLoad, 0); continue }
                XCTAssertGreaterThan(i.suggestedLoad, 0, "\(name) \(i.exerciseId): filled (\(before) were already loaded)")
                XCTAssertLessThanOrEqual(i.suggestedLoad, 95 + 1e-9, "\(name) \(i.exerciseId): never above 95% of the 100 lb working load")
                XCTAssertEqual(i.suggestedLoad, z.load, "\(name) \(i.exerciseId): the DeloadRule load")
                XCTAssertTrue(i.plannedLoadsBySet.allSatisfy { $0 == z.load }, "\(name) \(i.exerciseId): every slot \(i.plannedLoadsBySet)")
                XCTAssertEqual(i.coachNote, PlaceholderRefresh.deloadNote, name)
                XCTAssertFalse(i.planEdited, name)
            }
            for i in items where ExerciseCatalog.isBodyweight(exerciseId: i.exerciseId, customExercises: []) {
                XCTAssertEqual(i.suggestedLoad, 0, "\(name) \(i.exerciseId): bodyweight is never touched")
                XCTAssertNil(i.coachNote)
            }
            XCTAssertTrue(PlaceholderRefresh.run(in: ctx, now: now).isEmpty, "\(name): idempotent")
        }
        XCTAssertGreaterThanOrEqual(covered, 5, "the built-ins with a scheduled deload were all exercised")
        print("SDL| no-history (stay 0): \(noHistory)")
    }

    func test_editedItem_loggedWeek_insertedDeload_areLeftAlone_andNoHistoryStaysZero() throws {
        let ctx = try makeContext()
        let s = try seed(DUP10WeekTemplate.template, ctx)
        let items = s.week.flatMap(\.items)
        let edited = try XCTUnwrap(items.first)
        edited.planEdited = true; edited.suggestedLoad = 42; edited.plannedLoadsBySet = Array(repeating: 42, count: edited.targetSets)
        PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(edited.suggestedLoad, 42, "an edited item is never touched")
        XCTAssertTrue(items.dropFirst().contains { $0.suggestedLoad == 95 })

        // Recomputed every pass: a newer working session moves the load.
        let other = try XCTUnwrap(items.dropFirst().first { $0.suggestedLoad == 95 && $0.exerciseId != edited.exerciseId })
        func latestSource() -> SessionItem {
            s.all.filter { $0.status == .completed }.sorted { $0.date > $1.date }
                .compactMap { $0.items.first { $0.exerciseId == other.exerciseId } }.first!
        }
        let newer = latestSource()
        newer.actualLoads = Array(repeating: 120, count: newer.targetSets); newer.actualReps = Array(repeating: 8, count: newer.targetSets)
        PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertGreaterThan(other.suggestedLoad, 95, "a heavier newest working session raises the deload with it (recomputed every pass)")
        XCTAssertLessThanOrEqual(other.suggestedLoad, 114)

        // Once a set is logged in the deload week, the pass stops.
        let held = other.suggestedLoad
        let logged = try XCTUnwrap(items.first { $0 !== edited && $0 !== other })
        logged.actualLoads = [50]; logged.actualReps = [10]
        newer.actualLoads = Array(repeating: 200, count: newer.targetSets)
        PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertEqual(other.suggestedLoad, held, "a logged set in the deload week freezes it")
    }

    func test_inactiveHistory_leavesALiftWithNoWorkingLoadAtZero() throws {
        let ctx = try makeContext()
        let s = try seed(DUP10WeekTemplate.template, ctx)
        for sess in s.all { for i in sess.items { i.actualLoads = []; i.actualReps = []; i.actualRIRs = [] } }
        PlaceholderRefresh.run(in: ctx, now: now)
        XCTAssertTrue(s.week.flatMap(\.items).allSatisfy { $0.suggestedLoad == 0 }, "nothing to size from: stays 0")
    }
}


// MARK: - Re-add stress: remove -> re-add on a real seeded wave block, both entry points' sequences

@MainActor
final class WaveRestoreReAddStressTests: XCTestCase {

    private var parked: [ModelContainer] = []

    private func seeded() throws -> (ModelContainer, ModelContext) {
        let c = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        parked.append(c)
        let ctx = ModelContext(c)
        ctx.insert(User(units: .lb, progressionEnabled: true))
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: Date()))!
        let weekday = cal.component(.weekday, from: start)
        try DUPProgramSeeder.seed(startDate: start, trainingWeekdays: (0..<4).map { ((weekday - 1 + $0) % 7) + 1 }, context: ctx,
                                  template: UpperLower4DayTemplate.template, mesoName: "UL", mesoStatus: .active)
        try ctx.save()
        return (c, ctx)
    }

    /// Week 2, first day: a B week.
    private func target(_ ctx: ModelContext) throws -> Session {
        let all = try ctx.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)]))
        return try XCTUnwrap(all.first { $0.weekIndex == 2 })
    }

    private func generic(_ id: String, order: Int) -> SessionItem {
        let i = SessionItem(order: order, exerciseId: id, targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 0)
        i.plannedRepsBySet = Array(repeating: 10, count: 3); i.plannedLoadsBySet = Array(repeating: 0, count: 3)
        i.plannedRIRsBySet = Array(repeating: 2, count: 3); i.actualReps = Array(repeating: 0, count: 3)
        i.actualLoads = Array(repeating: 0, count: 3); i.actualRIRs = RIREntry.unsetArray(count: 3)
        return i
    }

    /// The Program tab's performDelete: out of session.items, the object kept (for Undo), saved.
    private func programRemove(_ item: SessionItem, from s: Session, _ ctx: ModelContext) throws {
        let idx = try XCTUnwrap(s.items.firstIndex { $0.id == item.id })
        let order = s.items[idx].order
        s.items.remove(at: idx)
        for o in s.items where o.order > order { o.order -= 1 }
        try ctx.save()
    }

    private func assertRestored(_ item: SessionItem, expected: (sets: Int, repMin: Int, repMax: Int, letter: String), _ note: String) {
        XCTAssertEqual(item.waveRaw, expected.letter, note)
        XCTAssertEqual([item.targetSets, item.repMin ?? -1, item.repMax ?? -1], [expected.sets, expected.repMin, expected.repMax], note)
    }

    func test_removeThenReAdd_tenTimes_everyVariant_alwaysComesBackAsTheSlotsPrescription() throws {
        let (container, ctx) = try seeded()
        let s = try target(ctx)
        let original = try XCTUnwrap(s.items.first { $0.exerciseId == "bench_press" })
        let want = (sets: original.targetSets, repMin: original.repMin ?? -1, repMax: original.repMax ?? -1, letter: original.waveRaw ?? "")
        XCTAssertEqual(want.letter, "b")

        // Variants: 0 Program tab, same context, immediately after the remove. 1 Program tab, fresh context (relationships not yet
        // faulted in). 2 Today, same context, the item inserted after restore. 3 Today with a fresh context. 4 hard delete (no Undo object
        // kept) then add. 5 the add happens before the remove's save is flushed (autosave off, no save between).
        for variant in 0...5 {
            for round in 1...10 {
                let note = "variant \(variant) round \(round)"
                let work = (variant == 1 || variant == 3) ? ModelContext(container) : ctx
                let session = try XCTUnwrap(try work.fetch(FetchDescriptor<Session>()).first { $0.persistentModelID == s.persistentModelID })
                guard let current = session.items.first(where: { $0.exerciseId == "bench_press" }) else { return XCTFail("bench missing \(note)") }
                if variant == 4 { session.items.removeAll { $0.id == current.id }; work.delete(current); try work.save() }
                else if variant == 5 { session.items.removeAll { $0.id == current.id } }          // not saved yet
                else { try programRemove(current, from: session, work) }
                XCTAssertNil(session.items.first { $0.exerciseId == "bench_press" }, note)

                let new = generic("bench_press", order: (session.items.map(\.order).max() ?? 0) + 1)
                let all = (try? work.fetch(FetchDescriptor<Session>())) ?? []
                XCTAssertTrue(WaveSlotRestore.restore(new, in: session, allSessions: all, entry: "stress v\(variant) r\(round)"), note)
                session.items.append(new)
                if variant == 2 || variant == 3 { work.insert(new) }
                try work.save()
                assertRestored(new, expected: want, note)
                // Re-read from the store: what was saved is what was restored.
                let reread = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<SessionItem>()).first { $0.id == new.id })
                assertRestored(reread, expected: want, note + " (re-read)")
            }
        }
    }

    func test_restoreOnASessionWithNoLoadedItems_orNoMeso_degradesToNothingWrongRatherThanTheGenericItemPassingAsRestored() throws {
        let (_, ctx) = try seeded()
        let s = try target(ctx)
        let all = try ctx.fetch(FetchDescriptor<Session>())
        // Wave context unavailable: every item gone (nothing to read the letter from) -> not restored, and it says so.
        let emptyCopy = Session(date: s.date, status: .planned, weekIndex: s.weekIndex, dayLabel: s.dayLabel, items: [])
        let new = generic("bench_press", order: 1)
        XCTAssertFalse(WaveSlotRestore.restore(new, in: emptyCopy, allSessions: all, entry: "stress no-context"))
        XCTAssertNil(new.waveRaw)
        // A session whose only remaining item is the one being re-added still reads the letter from the block.
        let only = try XCTUnwrap(s.items.first { $0.exerciseId == "bench_press" })
        for i in s.items where i !== only { s.items.removeAll { $0.id == i.id } }
        let again = generic("bench_press", order: 2)
        XCTAssertTrue(WaveSlotRestore.restore(again, in: s, allSessions: all, entry: "stress one-item"))
        XCTAssertEqual(again.waveRaw, "b")
    }
}


// MARK: - New planned sets copy the set before them; a re-added exercise takes its load at once

@MainActor
final class NewPlannedSetAndReAddLoadTests: XCTestCase {

    private var parked: [ModelContainer] = []
    private let cal = Calendar.current

    private func ctx() throws -> ModelContext {
        let c = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        parked.append(c)
        return ModelContext(c)
    }

    /// A 2-set item with the four array slots the Program editor keeps: the third and fourth are empty padding.
    private func twoSetItem(_ id: String = "lying_leg_curl", load: Double = 115, reps: Int = 12, rir: Int = 2, wave: String = "c") -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: id, targetReps: reps, targetSets: 2, targetRIR: rir, suggestedLoad: load,
                            waveRaw: wave, priorityRaw: "standard", setMin: 2, setMax: 2, repMin: reps, repMax: reps, targetRIRMin: rir, targetRIRMax: rir,
                            plannedRepsBySet: [reps, reps, 0, 0], plannedLoadsBySet: [load, load, 0, 0], plannedRIRsBySet: [rir, rir, 0, 0])
        return i
    }

    private func block(_ c: ModelContext, items: [[SessionItem]], statuses: [SessionStatus]? = nil, label: String = "Legs A") -> (MesoBlock, [Session]) {
        let meso = MesoBlock(name: "12-Week DUP Meso", startDate: cal.date(byAdding: .day, value: -30, to: Date())!, status: .active, totalWeeks: 12)
        meso.createdAt = cal.date(byAdding: .day, value: -40, to: Date())
        c.insert(meso)
        var out: [Session] = []
        for (n, its) in items.enumerated() {
            let status = statuses?[n] ?? .planned
            // Past sessions are completed, future ones planned, one a week.
            let date = cal.date(byAdding: .day, value: (n - items.count + 2) * 7, to: cal.startOfDay(for: Date()))!
            let s = Session(date: date, status: status, weekIndex: n + 1, dayLabel: label, items: its)
            s.meso = meso; meso.sessions.append(s); c.insert(s); out.append(s)
        }
        try? c.save()
        return (meso, out)
    }

    // MARK: sets increase

    func test_programEditorStepper_aNewSetCopiesThePreviousSet() throws {
        let item = twoSetItem()
        PlanStepperEdits.setSets(item, to: 3)
        XCTAssertEqual(item.targetSets, 3)
        XCTAssertEqual(Array(item.plannedLoadsBySet.prefix(3)), [115, 115, 115])
        XCTAssertEqual(Array(item.plannedRepsBySet.prefix(3)), [12, 12, 12])
        XCTAssertEqual(Array(item.plannedRIRsBySet.prefix(3)), [2, 2, 2])
        PlanStepperEdits.setSets(item, to: 4)
        XCTAssertEqual(Array(item.plannedLoadsBySet.prefix(4)), [115, 115, 115, 115])
        // Down and up again never resurrects a padding zero.
        PlanStepperEdits.setSets(item, to: 2); PlanStepperEdits.setSets(item, to: 3)
        XCTAssertEqual(Array(item.plannedLoadsBySet.prefix(3)), [115, 115, 115])
    }

    func test_programEditorStepper_aGrownSetAfterAHandEditCopiesTheEditedPreviousSet() throws {
        let item = twoSetItem()
        item.plannedLoadsBySet[1] = 125; item.plannedRepsBySet[1] = 10; item.plannedRIRsBySet[1] = 1
        PlanStepperEdits.setSets(item, to: 3)
        XCTAssertEqual([item.plannedLoadsBySet[2], Double(item.plannedRepsBySet[2]), Double(item.plannedRIRsBySet[2])], [125, 10, 1])
    }

    func test_changePrescription_setDeltaPlusOne_copiesTheLastPlannedSet_notAPaddingSlot() throws {
        let c = try ctx()
        let (meso, ss) = block(c, items: [[twoSetItem()], [twoSetItem()]])
        let plan = SessionItemEditService.planChangePrescription(meso: meso, dayLabel: "Legs A", exerciseId: "lying_leg_curl", scope: .allRemaining,
                                                                 change: PrescriptionChange(setDelta: 1), now: Date(timeIntervalSince1970: 0))
        try SessionItemEditService.applyChange(plan, in: c)
        for s in ss {
            let i = s.items[0]
            XCTAssertEqual(i.targetSets, 3)
            XCTAssertEqual(i.plannedLoadsBySet, [115, 115, 115])
            XCTAssertEqual(i.plannedRepsBySet, [12, 12, 12])
            XCTAssertEqual(i.plannedRIRsBySet, [2, 2, 2])
        }
    }

    func test_itemWithATopSet_growsItsBackOffsFromThePlannedRows_andKeepsTheTop() throws {
        let i = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 2, targetRIR: 2, suggestedLoad: 200,
                            plannedRepsBySet: [8, 8, 4], plannedLoadsBySet: [200, 200, 240], plannedRIRsBySet: [2, 2, 1])
        i.setRolesBySet = SessionItem.roles(backOffs: 2, tops: 1); i.topRepMin = 4; i.topRepMax = 4; i.topRIR = 1
        PlanStepperEdits.setSets(i, to: 3)
        XCTAssertEqual(i.plannedLoadsBySet, [200, 200, 200, 240])
        XCTAssertEqual(i.plannedRepsBySet, [8, 8, 8, 4])
        XCTAssertEqual(i.plannedRIRsBySet, [2, 2, 2, 1])
    }

    // MARK: the startup repair

    func test_repair_fillsAnEmptyNewSetFromTheOneBefore_andIsIdempotent() throws {
        let c = try ctx()
        // The Dec 12 shape: targetSets 3, planned 3rd set empty.
        let lc = twoSetItem(); lc.targetSets = 3; lc.setMax = 3; lc.planEdited = true
        let ext = twoSetItem("leg_extension", load: 195); ext.targetSets = 3
        let ok = twoSetItem("hack_squat", load: 300); ok.targetSets = 3; ok.plannedLoadsBySet = [300, 300, 300, 0]; ok.plannedRepsBySet = [12, 12, 12, 0]; ok.plannedRIRsBySet = [2, 2, 2, 0]
        let none = twoSetItem("leg_press", load: 0); none.targetSets = 3; none.plannedLoadsBySet = [0, 0, 0, 0]
        let (_, ss) = block(c, items: [[lc, ext, ok, none]])
        let fixes = PlannedSetRepair.run(in: c)
        XCTAssertEqual(fixes.count, 2)
        XCTAssertEqual(Array(lc.plannedLoadsBySet.prefix(3)), [115, 115, 115]); XCTAssertEqual(Array(lc.plannedRepsBySet.prefix(3)), [12, 12, 12])
        XCTAssertEqual(Array(lc.plannedRIRsBySet.prefix(3)), [2, 2, 2]); XCTAssertEqual(lc.plannedLoadsBySet.count, 4, "the padding slot stays")
        XCTAssertEqual(Array(ext.plannedLoadsBySet.prefix(3)), [195, 195, 195])
        XCTAssertTrue(lc.planEdited, "the repair is not a lifter edit and does not touch the flag")
        XCTAssertEqual(ok.plannedLoadsBySet, [300, 300, 300, 0], "a complete item, and its padding slot, are untouched")
        XCTAssertEqual(none.plannedLoadsBySet, [0, 0, 0, 0], "no earlier load to copy")
        XCTAssertTrue(PlannedSetRepair.plan(sessions: ss).isEmpty, "a second pass changes nothing")
    }

    func test_repair_neverTouchesLoggedCompletedBodyweightOrTopRows() throws {
        let c = try ctx()
        let done = twoSetItem("lying_leg_curl", load: 115); done.targetSets = 3
        let logged = twoSetItem("seated_leg_curl", load: 100); logged.targetSets = 3; logged.actualReps = [12, 12, 0, 0]; logged.actualLoads = [100, 100, 0, 0]
        let bw = twoSetItem("pull_up", load: 0); bw.targetSets = 3; bw.plannedLoadsBySet = [10, 10, 0, 0]
        let top = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 2, targetRIR: 2, suggestedLoad: 200,
                              plannedRepsBySet: [8, 8, 4], plannedLoadsBySet: [200, 200, 0], plannedRIRsBySet: [2, 2, 1])
        top.setRolesBySet = SessionItem.roles(backOffs: 2, tops: 1); top.topRepMin = 4; top.topRepMax = 4; top.topRIR = 1
        _ = block(c, items: [[done], [logged, bw, top]], statuses: [.completed, .planned])
        let before = (done.plannedLoadsBySet, logged.plannedLoadsBySet, bw.plannedLoadsBySet, top.plannedLoadsBySet)
        XCTAssertTrue(PlannedSetRepair.run(in: c).isEmpty)
        XCTAssertEqual(done.plannedLoadsBySet, before.0); XCTAssertEqual(logged.plannedLoadsBySet, before.1)
        XCTAssertEqual(bw.plannedLoadsBySet, before.2); XCTAssertEqual(top.plannedLoadsBySet, before.3, "an empty top row is not a back-off row")
    }

    // MARK: a re-added exercise takes its load

    private func generic(_ id: String, order: Int = 9) -> SessionItem {
        let i = SessionItem(order: order, exerciseId: id, targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 0)
        i.plannedRepsBySet = [10, 10, 10]; i.plannedLoadsBySet = [0, 0, 0]; i.plannedRIRsBySet = [2, 2, 2]
        i.actualReps = [0, 0, 0]; i.actualLoads = [0, 0, 0]; i.actualRIRs = RIREntry.unsetArray(count: 3)
        return i
    }

    private func performed(_ id: String, wave: String, load: Double, reps: Int = 12, sets: Int = 3) -> SessionItem {
        let i = SessionItem(order: 1, exerciseId: id, targetReps: reps, targetSets: sets, targetRIR: 2, suggestedLoad: load, waveRaw: wave,
                            priorityRaw: "standard", setMin: sets, setMax: sets, repMin: reps, repMax: reps + 2, targetRIRMin: 2, targetRIRMax: 2,
                            plannedRepsBySet: Array(repeating: reps, count: sets), plannedLoadsBySet: Array(repeating: load, count: sets),
                            plannedRIRsBySet: Array(repeating: 2, count: sets),
                            actualReps: Array(repeating: reps, count: sets), actualLoads: Array(repeating: load, count: sets), actualRIRs: Array(repeating: 2, count: sets))
        return i
    }

    private func template(_ id: String, wave: String) -> SessionItem {
        let i = performed(id, wave: wave, load: 0)
        i.actualReps = []; i.actualLoads = []; i.actualRIRs = []
        return i
    }

    func test_reAdd_sameLetterPerformed_holdsThePerformedLoad_withTheNote_atOnce() throws {
        let c = try ctx()
        let id = "cable_tricep_rope_pushdown"
        // Week 1 (completed, letter c, 85 x 12 x 3), week 2 (planned, letter c; the other exercise keeps the wave readable) where it is re-added.
        let (_, ss) = block(c, items: [[performed(id, wave: "c", load: 85), performed("bench_press", wave: "c", load: 200)],
                                       [template("bench_press", wave: "c")]], statuses: [.completed, .planned], label: "Push B")
        let target = ss[1]
        let new = generic(id)
        XCTAssertTrue(WaveSlotRestore.restore(new, in: target, allSessions: ss))
        target.items.append(new); c.insert(new)
        XCTAssertEqual(new.suggestedLoad, 0)
        let changes = PlaceholderRefresh.refreshNewItem(new, in: c)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(new.suggestedLoad, 85)
        XCTAssertEqual(new.plannedLoadsBySet, [85, 85, 85])
        XCTAssertTrue(new.coachNote?.contains("Held at 85") == true, new.coachNote ?? "nil")
        XCTAssertFalse(new.planEdited, "an automatic write")
    }

    func test_reAdd_otherLetterOnly_isEstimated_andNoHistoryGetsTheNote() throws {
        let c = try ctx()
        let id = "cable_tricep_rope_pushdown"
        // Only a B-letter session of the day has performed it: the cross-letter estimate applies to the C-letter re-add.
        let (_, ss) = block(c, items: [[performed(id, wave: "b", load: 100, reps: 10), performed("bench_press", wave: "b", load: 200)],
                                       [template("bench_press", wave: "c")]], statuses: [.completed, .planned], label: "Push B")
        let new = generic(id)
        XCTAssertTrue(WaveSlotRestore.restore(new, in: ss[1], allSessions: ss)); ss[1].items.append(new); c.insert(new)
        PlaceholderRefresh.refreshNewItem(new, in: c)
        XCTAssertGreaterThan(new.suggestedLoad, 0, "estimated from the B-week sets")
        XCTAssertTrue(new.coachNote?.contains("Estimated from your recent B-week sets") == true, new.coachNote ?? "nil")

        // Nothing performed anywhere: stays 0 with the one-time note.
        let c2 = try ctx()
        let (_, s2) = block(c2, items: [[template("bench_press", wave: "c")]], label: "Push B")
        let lone = generic("lying_leg_curl")
        XCTAssertTrue(WaveSlotRestore.restore(lone, in: s2[0], allSessions: s2)); s2[0].items.append(lone); c2.insert(lone)
        PlaceholderRefresh.refreshNewItem(lone, in: c2)
        XCTAssertEqual(lone.suggestedLoad, 0)
        XCTAssertTrue(lone.prescriptionNotes?.contains(PlaceholderRefresh.noRecentHistoryNote) == true)
    }

    func test_refreshNewItem_isOnlyThatItem_andRespectsTheSwitch() throws {
        let c = try ctx()
        let id = "cable_tricep_rope_pushdown"
        let stale = template("bench_press", wave: "c"); stale.suggestedLoad = 0; stale.plannedLoadsBySet = [0, 0, 0]
        let (_, ss) = block(c, items: [[performed(id, wave: "c", load: 85), performed("bench_press", wave: "c", load: 200)], [stale]],
                            statuses: [.completed, .planned], label: "Push B")
        let new = generic(id)
        XCTAssertTrue(WaveSlotRestore.restore(new, in: ss[1], allSessions: ss)); ss[1].items.append(new); c.insert(new)
        PlaceholderRefresh.isEnabled = false
        XCTAssertTrue(PlaceholderRefresh.refreshNewItem(new, in: c).isEmpty); XCTAssertEqual(new.suggestedLoad, 0)
        PlaceholderRefresh.isEnabled = true
        PlaceholderRefresh.refreshNewItem(new, in: c)
        XCTAssertEqual(new.suggestedLoad, 85)
        XCTAssertEqual(stale.suggestedLoad, 0, "the startup pass's other candidates are not touched by the single-item pass")
    }
}


// MARK: - The refresh reads explicit facts, and every write stamps updatedAt

@MainActor
final class LoadEverWrittenAndStampTests: XCTestCase {

    private var parked: [ModelContainer] = []
    private let cal = Calendar.current
    private func ctx() throws -> ModelContext {
        let c = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        parked.append(c); return ModelContext(c)
    }
    private let old = Date(timeIntervalSince1970: 1_700_000_000)

    private func item(load: Double = 100, sets: Int = 3) -> SessionItem {
        SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: sets, targetRIR: 2, suggestedLoad: load, waveRaw: "a",
                    priorityRaw: "anchor", repMin: 6, repMax: 8, targetRIRMin: 2, targetRIRMax: 2,
                    plannedRepsBySet: Array(repeating: 8, count: sets), plannedLoadsBySet: Array(repeating: load, count: sets), plannedRIRsBySet: Array(repeating: 2, count: sets))
    }

    func test_newItemsStartAtFalse_andAnyLoadWriteSetsTrue_whileOtherWritesOnlyStamp() {
        let i = item()
        XCTAssertEqual(i.loadEverWritten, false)
        i.updatedAt = old
        var fp = i.writeFingerprint()
        i.coachNote = "a note"
        XCTAssertTrue(i.stampIfChanged(since: fp))
        XCTAssertGreaterThan(i.updatedAt ?? old, old, "a note is a write: updatedAt moves")
        XCTAssertEqual(i.loadEverWritten, false, "but no load was written")
        fp = i.writeFingerprint(); i.updatedAt = old
        XCTAssertFalse(i.stampIfChanged(since: fp), "nothing changed: nothing stamped")
        XCTAssertEqual(i.updatedAt, old)
        fp = i.writeFingerprint()
        i.plannedLoadsBySet = [105, 105, 105]
        XCTAssertTrue(i.stampIfChanged(since: fp))
        XCTAssertEqual(i.loadEverWritten, true)
    }

    func test_everyWritePath_stamps() throws {
        // The lifter's steppers.
        let a = item(); a.updatedAt = old
        PlanStepperEdits.setPlannedLoad(a, at: 0, to: 110)
        XCTAssertGreaterThan(a.updatedAt ?? old, old); XCTAssertEqual(a.loadEverWritten, true)
        let b = item(); b.updatedAt = old
        PlanStepperEdits.setRIR(b, to: 1)
        XCTAssertGreaterThan(b.updatedAt ?? old, old); XCTAssertEqual(b.loadEverWritten, false, "an RIR edit is not a load write")
    }

    func test_refresh_stampsItsOwnWrites() throws {
        let c = try ctx()
        let meso = MesoBlock(name: "M", startDate: cal.date(byAdding: .day, value: -30, to: Date())!, status: .active, totalWeeks: 12)
        meso.createdAt = cal.date(byAdding: .day, value: -40, to: Date()); c.insert(meso)
        let done = item(load: 100); done.actualReps = [8, 8, 8]; done.actualLoads = [100, 100, 100]; done.actualRIRs = [2, 2, 2]; done.loadEverWritten = true
        let target = item(load: 0); target.updatedAt = old
        let s1 = Session(date: cal.date(byAdding: .day, value: -7, to: Date())!, status: .completed, weekIndex: 1, dayLabel: "Push A", items: [done])
        let s2 = Session(date: cal.date(byAdding: .day, value: 7, to: Date())!, status: .planned, weekIndex: 4, dayLabel: "Push A", items: [target])
        for s in [s1, s2] { s.meso = meso; meso.sessions.append(s); c.insert(s) }
        XCTAssertEqual(target.loadEverWritten, false)
        let changes = PlaceholderRefresh.run(in: c)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(target.suggestedLoad, 100)
        XCTAssertGreaterThan(target.updatedAt ?? old, old, "the refresh stamps what it writes")
        XCTAssertEqual(target.loadEverWritten, true)
    }

    func test_theRefreshNoLongerReadsUpdatedAt() throws {
        // A target still at its block-setup value, a source that cannot give a load: the one-time placeholder note comes from
        // loadEverWritten == false, whatever updatedAt says. Flip the explicit fact and the note goes; moving updatedAt changes nothing.
        func run(written: Bool, updatedAt: Date?) throws -> String? {
            let c = try ctx()
            let meso = MesoBlock(name: "M", startDate: cal.date(byAdding: .day, value: -30, to: Date())!, status: .active, totalWeeks: 12)
            meso.createdAt = cal.date(byAdding: .day, value: -40, to: Date()); c.insert(meso)
            let dayLabel = "Push A"
            let high = item(load: 30); high.exerciseId = "dumbbell_lateral_raise"; high.waveRaw = "c"
            high.actualReps = [18, 18, 18]; high.actualLoads = [30, 30, 30]; high.actualRIRs = [2, 2, 2]; high.repMin = 15; high.repMax = 20; high.targetReps = 15
            let done = Session(date: cal.date(byAdding: .day, value: -7, to: Date())!, status: .completed, weekIndex: 1, dayLabel: dayLabel, items: [high])
            let t = item(load: 33); t.exerciseId = "dumbbell_lateral_raise"; t.waveRaw = "a"; t.repMin = 10; t.repMax = 12; t.targetReps = 10
            t.updatedAt = updatedAt; t.loadEverWritten = written
            let planned = Session(date: cal.date(byAdding: .day, value: 7, to: Date())!, status: .planned, weekIndex: 4, dayLabel: dayLabel, items: [t])
            for s in [done, planned] { s.meso = meso; meso.sessions.append(s); c.insert(s) }
            PlaceholderRefresh.run(in: c)
            return t.coachNote
        }
        let never = try run(written: false, updatedAt: nil)
        XCTAssertEqual(never, PlaceholderRefresh.placeholderNote, "not written since setup: the one-time note")
        XCTAssertEqual(try run(written: false, updatedAt: Date()), PlaceholderRefresh.placeholderNote, "a fresh updatedAt does not make it 'written'")
        XCTAssertNil(try run(written: true, updatedAt: old), "written: no note, whatever the timestamp")
    }

    func test_carryOverBackfill_readsTheOldUpdatedAtRuleOnce_andIsIdempotent() throws {
        let c = try ctx()
        let meso = MesoBlock(name: "M", startDate: old, status: .active, totalWeeks: 12)
        meso.createdAt = old; c.insert(meso)
        let written = item(); written.updatedAt = old.addingTimeInterval(3600); written.loadEverWritten = nil
        let notWritten = item(); notWritten.updatedAt = old.addingTimeInterval(30); notWritten.loadEverWritten = nil     // within the minute's grace
        let unknown = item(); unknown.updatedAt = nil; unknown.loadEverWritten = nil                                      // no date: counted as written
        let already = item(); already.loadEverWritten = false; already.updatedAt = old.addingTimeInterval(9999)
        let s = Session(date: Date(), status: .planned, weekIndex: 1, dayLabel: "D", items: [written, notWritten, unknown, already])
        s.meso = meso; meso.sessions.append(s); c.insert(s)
        XCTAssertEqual(LoadEverWrittenBackfill.run(in: c), 3, "only the three nil items")
        XCTAssertEqual([written.loadEverWritten, notWritten.loadEverWritten, unknown.loadEverWritten, already.loadEverWritten], [true, false, true, false])
        XCTAssertEqual(LoadEverWrittenBackfill.run(in: c), 0, "idempotent: nothing is nil now")
    }

    func test_theFlagRoundTripsThroughABackup() throws {
        let c = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let ctx = ModelContext(c)
        let on = item(), off = item(), unknown = item()
        on.loadEverWritten = true; off.loadEverWritten = false; unknown.loadEverWritten = nil
        for (n, i) in [on, off, unknown].enumerated() { i.order = n + 1 }
        let s = Session(date: Date(), status: .planned, weekIndex: 1, dayLabel: "D", items: [on, off, unknown]); ctx.insert(s)
        try ctx.save()
        let target = try BackupTestSupport.makeContainer()
        _ = try BackupTestSupport.restore(from: ctx, into: target)
        let restored = try ModelContext(target).fetch(FetchDescriptor<SessionItem>()).sorted { $0.order < $1.order }
        XCTAssertEqual(restored.map(\.loadEverWritten), [true, false, nil])
    }
}
